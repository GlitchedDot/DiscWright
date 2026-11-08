// Imapi2Interop.cs — what's left of the hand-rolled IMAPI2
// declarations: the one shell API the burn needs (an IStream
// over the ISO). The COM class declarations that used to
// live here are gone — BurnService creates the IMAPI2
// objects by ProgID and drives them as `dynamic` (see
// BurnService.CreateImapi, and the history below for why).
//
// HOW THE OBJECTS ARE USED — ALL `dynamic`, NO TYPED
// INTERFACES (v24; the history matters, it cost three builds):
//   v22 created the objects via Activator.CreateInstance(
//   Type.GetTypeFromCLSID(...)) and cast to a typed
//   IDiscMaster2 interface — the cast died E_NOINTERFACE on
//   a bare System.__ComObject before any recorder was read.
//   v23 switched creation to the ComImport coclasses below —
//   the object then WAS a genuine MsftDiscMaster2, and the
//   cast STILL died E_NOINTERFACE. A standalone probe on the
//   same machine (bare STA console app, 2026-11-06) settled
//   it: the typed cast fails there too, while the dynamic /
//   IDispatch route enumerates the recorder perfectly
//   (Count = 1, Item(0) = the slimtype USB DVD drive). The
//   typed route needs a per-interface marshaling proxy that
//   does not resolve on that Windows install; IDispatch uses
//   the universal marshaler and needs none. So BurnService
//   drives every IMAPI2 object through `dynamic`: member
//   names resolve at run time, and any mistake surfaces as a
//   logged runtime error — never a silent wrong call or a
//   faked success. The typed interface declarations that used
//   to live here were removed in v24; the probe project
//   (discwright-burnprobe) preserves the evidence.
//   v25 finished the job: the coclass declarations are gone
//   too. Burn probe 2 read the registry on Lola's PC and
//   caught the baked-in GUID table in a lie —
//   IMAPI2.MsftDiscRecorder2 is registered there as CLSID
//   2735412D, not the 2735412F the tables claim, so v24's
//   hardcoded creation died REGDB_E_CLASSNOTREG while a
//   ProgID-resolved creation initialized fine. BurnService
//   now creates every IMAPI2 object by ProgID (CreateImapi),
//   resolving the CLSID from the running machine's own
//   registration. (For the record, her registry's table:
//   MsftDiscMaster2 2735412E, MsftDiscRecorder2 2735412D,
//   MsftDiscFormat2Data 2735412A — all in imapi2.dll.)

using System;
using System.Runtime.InteropServices;
using ComIStream = System.Runtime.InteropServices.ComTypes.IStream;

namespace DiscWright;

/// <summary>The one API the burn needs from the shell:
/// an IStream over the ISO file.</summary>
public static class Imapi2
{
    private const uint StgmRead = 0x00000000;
    private const uint StgmShareDenyWrite = 0x00000020;

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateStreamOnFileEx(
        string pszFile,
        uint grfMode,
        uint dwAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool fCreate,
        ComIStream? pstmTemplate,
        out ComIStream? ppstm);

    /// <summary>Open `path` as a COM IStream (read-only,
    /// deny-write sharing — the mode Microsoft's IMAPI samples
    /// use). Throws COMException on failure.</summary>
    public static ComIStream OpenFileStream(string path)
    {
        int hr = SHCreateStreamOnFileEx(
            path, StgmRead | StgmShareDenyWrite, 0, false, null,
            out ComIStream? stream);
        if (hr != 0 || stream == null)
            throw new COMException(
                $"SHCreateStreamOnFileEx failed for {path}", hr);
        return stream;
    }
}
