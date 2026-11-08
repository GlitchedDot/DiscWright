// BurnService.cs — the burn, the Windows counterpart of the
// Mac's BurnService.swift: a confirmation dialog ("Burn this
// disc now?"), the burn itself, then a result dialog. Where
// the Mac shells out to drutil, Windows has the burner built
// in: IMAPI2's MsftDiscFormat2Data writes a ready ISO stream
// straight to the disc (see Imapi2Interop.cs for the interop
// shape and its stated risks).
//
// Honesty rules, same as the Mac: the service reports
// .started while the burn runs and .finished with the REAL
// outcome; every failure is logged with its HRESULT. Nothing
// in here pretends a burn happened.
//
// One structural divergence from Swift, forced by WinUI: the
// confirmation dialog needs a Window (for XamlRoot), so
// MainWindow calls OfferBurnAsync and forwards the state
// callbacks into the store (DiscStore.ApplyBurnState) — the
// state machine itself is the Mac's, unchanged.

using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DiscWright;

public static class BurnService
{
    /// <summary>offerBurn(iso, source): "Burn this disc now?" —
    /// the Mac wording, verbatim, in two origins (v32): a disc
    /// the app itself just encoded says it is "encoded and
    /// ready"; a genuinely imported ISO says it is "imported".
    /// Reports BurnState.Started while IMAPI2 writes and
    /// BurnState.Finished with the outcome, and logs the burn's
    /// own messages through `log` (the drutil-output
    /// equivalent).</summary>
    public static async Task OfferBurnAsync(
        Window window,
        ImportedDisc disc,
        Action<BurnState, bool> onState,
        Action<string> log)
    {
        var dialog = new ContentDialog
        {
            Title = "Burn this disc now?",
            Content = disc.FromEncode
                ? $"“{disc.Name}” — Your disc is encoded and ready. Put a blank CD in the drive, then burn it."
                : $"“{disc.Name}” — You imported this ISO. Put a blank CD in the drive, then burn it.",
            PrimaryButtonText = "Burn Disc",
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = window.Content?.XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        var queue = window.DispatcherQueue;
        void Report(BurnState state, bool success) =>
            queue.TryEnqueue(() => onState(state, success));
        void Log(string line) => queue.TryEnqueue(() => log(line));

        // IMAPI2 work happens off the UI thread, on an STA
        // thread (the apartment COM samples standardise on).
        var thread = new Thread(() =>
        {
            Report(BurnState.Started, false);
            var (success, summary) = BurnIso(disc.FilePath, disc.Name, Log);
            Report(BurnState.Finished, success);
            queue.TryEnqueue(async () =>
            {
                var done = new ContentDialog
                {
                    Title = success ? "Burn finished" : "Burn failed",
                    Content = summary,
                    CloseButtonText = "OK",
                    XamlRoot = window.Content?.XamlRoot,
                };
                try { await done.ShowAsync(); }
                catch { /* a result dialog must never crash the app */ }
            });
        })
        { IsBackground = true, Name = "DiscWright burn" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>Create an IMAPI2 object by its ProgID,
    /// resolving the CLSID from THIS machine's registration
    /// at run time. Why (v25): the coclass GUIDs baked into
    /// source were wrong for the recorder — Lola's PC
    /// registers IMAPI2.MsftDiscRecorder2 as 2735412D, not
    /// the 2735412F the reference tables (and our interop
    /// file) claimed, so the hardcoded creation died
    /// REGDB_E_CLASSNOTREG while the ProgID-resolved one
    /// initialized fine (burn probe 2, 2026-11-06). ProgID
    /// resolution asks the registry every time, so it cannot
    /// drift from the machine it runs on.</summary>
    private static dynamic CreateImapi(string progId)
    {
        var type = Type.GetTypeFromProgID(progId)
            ?? throw new InvalidOperationException(
                $"IMAPI2 class {progId} is not registered on this system.");
        return Activator.CreateInstance(type)!;
    }

    /// <summary>The burn itself, synchronously, on the STA
    /// thread: first recorder, MsftDiscFormat2Data, the ISO as
    /// an IStream. ForceMediaToBeClosed is left FALSE (the
    /// IMAPI default): the disc stays open for later sessions,
    /// SonicStage's habit — and the Mac evidence already proved
    /// a plain single-session burn plays on the D-NE1, so this
    /// is a bonus, not a requirement.</summary>
    private static (bool success, string summary) BurnIso(
        string isoPath, string isoName, Action<string> log)
    {
        try
        {
            // --- enumerate recorders ---
            // ALL IMAPI2 objects are driven through `dynamic`
            // (IDispatch) in this service. Why (v24, proven by
            // the burn probe on Lola's gaming PC, 2026-11-06):
            // casting a genuine MsftDiscMaster2 object to the
            // typed IDiscMaster2 interface fails E_NOINTERFACE
            // even in a bare STA console app on her machine —
            // the typed route needs a per-interface marshaling
            // proxy that does not resolve there — while the
            // IDispatch route (universal marshaler) enumerated
            // her recorder perfectly: Count = 1, Item(0) = the
            // slimtype USB DVD drive. See Imapi2Interop.cs.
            dynamic master = CreateImapi("IMAPI2.MsftDiscMaster2");
            int count = master.Count;
            if (count <= 0)
            {
                log("IMAPI2: no CD/DVD recorder was found.");
                return (false, "No CD/DVD recorder was found on this system.");
            }
            string uniqueId = master.Item(0);

            dynamic recorder = CreateImapi("IMAPI2.MsftDiscRecorder2");
            recorder.InitializeDiscRecorder(uniqueId);

            // --- the data writer (also dynamic, as before) ---
            dynamic writer = CreateImapi("IMAPI2.MsftDiscFormat2Data");
            writer.Recorder = recorder;
            bool recorderSupported = writer.IsRecorderSupported(recorder);
            if (!recorderSupported)
            {
                log("IMAPI2: the first recorder is not supported by the data format.");
                return (false, "The first CD/DVD recorder is not supported for data burning.");
            }
            bool mediaSupported = writer.IsCurrentMediaSupported(recorder);
            if (!mediaSupported)
            {
                log("IMAPI2: the disc in the drive is not supported media " +
                    "(a blank or appendable CD is required).");
                return (false, "The disc in the drive is not blank or appendable media IMAPI2 can write.");
            }
            writer.ClientName = "DiscWright";
            writer.ForceMediaToBeClosed = false;

            log($"IMAPI2: burning “{isoName}”…");
            var stream = Imapi2.OpenFileStream(isoPath);
            writer.Write(stream);
            log("IMAPI2: burn finished.");
            return (true,
                $"“{isoName}” was written to the disc in the first recorder.");
        }
        catch (COMException ex)
        {
            string msg = $"IMAPI2 burn failed (HRESULT 0x{ex.HResult:X8}): {ex.Message}";
            log(msg);
            return (false, msg);
        }
        catch (Exception ex)
        {
            string msg = $"Burn failed: {ex.Message}";
            log(msg);
            return (false, msg);
        }
    }
}
