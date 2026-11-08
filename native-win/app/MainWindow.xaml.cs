// MainWindow.xaml.cs — layout glue: the store's DataContext,
// the pickers (which need this window's handle in unpackaged
// WinUI), the capacity meter's fill (a width, so it lives in
// code), the row/group button handlers, and the disc canvas's
// route to DiscPainter. All list SEMANTICS live in DiscStore;
// this file only moves data between the window and the store,
// mirroring how the SwiftUI views call into DiscStore.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using DiscWright.Core;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.UI.ViewManagement;

namespace DiscWright;

public sealed partial class MainWindow : Window
{
    public DiscStore Store { get; } = new();
    private readonly DiscPainter _painter = new();

    private sealed class BlankOption
    {
        public required int Sectors { get; init; }
        public required string Label { get; init; }
    }

    public MainWindow()
    {
        InitializeComponent();

        // The titlebar icon: WinUI does not take it from the
        // exe's ApplicationIcon by itself — hand the window the
        // .ico the csproj copies beside the exe. Cosmetic, so
        // a failure here must never block startup (Lola's ask,
        // 2026-11-06: "put that icon in that top left spot of
        // the titlebar too").
        try
        {
            AppWindow.SetIcon(Path.Combine(
                AppContext.BaseDirectory, "DiscWright.ico"));
        }
        catch { /* the default icon is a shrug, not a stop */ }

        // Default size. v37 (Lola, 2026-11-07): the right
        // column's fixed stack — header, disc stage, status,
        // blank picker, capacity meter, action rows — adds up
        // taller than 880, and the layout quietly clipped the
        // bottom rows, which are exactly the encode's Cancel
        // button and the workers picker. She wants them
        // visible, always: 980 tall here, and the disc stage
        // gives back height on its side (440 -> 336 in the
        // XAML; the painter sizes the disc from the canvas it
        // is given). Together ~200 DIP of headroom, so the
        // whole column fits at the default size.
        AppWindow.Resize(new SizeInt32(1200, 980));

        RootGrid.DataContext = Store;
        ((CollectionViewSource)RootGrid.Resources["GroupsSource"]).Source =
            Store.Groups;

        _painter.Store = Store;
        _painter.ReduceMotion = !new UISettings().AnimationsEnabled;
        CompositionTarget.Rendering += OnDiscRendering;

        // The blank picker: the core's six, in the web's order,
        // plus Custom… (the Mac picker's shape).
        var options = DiscStore.BlankOptions
            .Select(s => new BlankOption { Sectors = s, Label = Capacity.Blanks[s] })
            .ToList();
        options.Add(new BlankOption { Sectors = -1, Label = "Custom…" });
        BlankCombo.ItemsSource = options;
        BlankCombo.DisplayMemberPath = nameof(BlankOption.Label);
        BlankCombo.SelectedIndex = 0; // 12 cm 80 min — the store's default

        // The encode-workers selector (Step 3): choices are
        // 1..this machine's core count, the selection is the
        // store's persisted setting (index = workers - 1).
        WorkersCombo.ItemsSource =
            Enumerable.Range(1, DiscStore.MaxWorkers).ToList();
        WorkersCombo.SelectedIndex = Store.EncodeWorkers - 1;

        Store.StateChanged += (_, _) => RefreshMeter();
        RootGrid.ActualThemeChanged += (_, _) => RefreshMeter();
        Store.LogLines.CollectionChanged += (_, _) =>
        {
            if (Store.LogLines.Count > 0)
                LogList.ScrollIntoView(Store.LogLines[Store.LogLines.Count - 1]);
        };
        RefreshMeter();
    }

    // ---- capacity meter (fill width + over-capacity color) ----

    private void MeterTrack_SizeChanged(object sender, SizeChangedEventArgs e) =>
        RefreshMeter();

    private void RefreshMeter()
    {
        double inner = Math.Max(0, MeterTrack.ActualWidth - 2);
        MeterFill.Width = inner * Math.Max(0, Math.Min(1, Store.CapacityFraction));
        MeterFill.Background = (Brush)Application.Current.Resources[
            Store.CapacityOver ? "MeterOverBrush" : "MeterFillBrush"];
        // Over capacity the text is the palette's bad red;
        // otherwise the palette's pane text (#e6e9ff dark /
        // #14141c light), picked by the live actual theme.
        CapacityTextBlock.Foreground = Store.CapacityOver
            ? (Brush)Application.Current.Resources["BadBrush"]
            : new SolidColorBrush(
                RootGrid.ActualTheme == ElementTheme.Dark
                    ? Windows.UI.Color.FromArgb(0xFF, 0xE6, 0xE9, 0xFF)
                    : Windows.UI.Color.FromArgb(0xFF, 0x14, 0x14, 0x1C));
    }

    // ---- pickers ----

    private IntPtr Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.MusicLibrary,
        };
        foreach (var ext in new[] { ".mp3", ".m4a", ".wav", ".flac", ".ogg", ".aif", ".aiff" })
            picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0)
            await Store.AddFilesAsync(files.Select(f => f.Path).ToList());
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.MusicLibrary,
        };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder != null) await Store.AddFolderAsync(folder.Path);
    }

    private void AddGroup_Click(object sender, RoutedEventArgs e) => Store.AddGroup();

    private async void ImportIso_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add(".iso");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file != null) Store.ImportIso(file.Path);
    }

    private void ClearImport_Click(object sender, RoutedEventArgs e) =>
        Store.ClearImport();

    // ---- burn (the dialog needs this window) ----

    private async void BurnDisc_Click(object sender, RoutedEventArgs e)
    {
        if (Store.Imported is { } imp)
        {
            await BurnService.OfferBurnAsync(
                this, imp,
                (state, success) => Store.ApplyBurnState(state, success),
                Store.Log);
            return;
        }
        await BurnNewDiscAsync();
    }

    // ---- encode (Step 3; driven by Burn Disc in the final
    // version) ----
    // Burn Disc on a new list: encode + author it (the ISO
    // still lands in Downloads\atrac-disc.iso, no physical
    // disc spent up front), then the window hands the fresh
    // ISO to the same proven Import ISO + OfferBurn path —
    // auto-imported and marked FromEncode, so the burn offer
    // follows the encode in one go. (v26–v31 surfaced this
    // through a temporary Make ISO button, Lola's test path;
    // removed in v32 at her word.) The orchestration mirrors
    // the Mac store's startEncodeAndBuild; the state flow
    // reports through the store, BurnService-style, via the
    // DispatcherQueue.

    private void WorkersCombo_SelectionChanged(
        object sender, SelectionChangedEventArgs e)
    {
        if (WorkersCombo.SelectedIndex >= 0)
            Store.EncodeWorkers = WorkersCombo.SelectedIndex + 1;
    }

    private void CancelEncode_Click(object sender, RoutedEventArgs e) =>
        Store.CancelEncode();

    private async Task BurnNewDiscAsync()
    {
        // Pre-flight, the Mac's build guards: refuse loudly
        // rather than author a disc with a hole in it.
        var tracks = Store.AllTracks;
        if (Store.Imported != null || tracks.Count == 0 || Store.IsEncoding) return;
        if (tracks.FirstOrDefault(t => t.Error != null) is { } bad)
        {
            Store.FailBeforeBuild(
                $"Cannot build: “{bad.Name}” could not be read when it was added.");
            return;
        }
        if (tracks.FirstOrDefault(t => t.FilePath == null) is { } missing)
        {
            Store.FailBeforeBuild(
                $"Cannot build: “{missing.Name}” has no source file.");
            return;
        }
        if (Store.CapacityOver)
        {
            Store.FailBeforeBuild(
                "Cannot build: the list is over the blank's capacity.");
            return;
        }
        if (EncodeService.MissingTool() is { } tool)
        {
            Store.FailBeforeBuild(
                $"Cannot build: {tool} is missing from the app's tools folder.");
            return;
        }

        // Snapshot the playlist (order is sacred) and the
        // groups as 1-based inclusive ranges over it, skipping
        // empty groups — the Mac's snapshot, in shape verbatim.
        var jobs = new List<EncodeJob>();
        var meta = new List<(string Title, string Artist, string Album)>();
        var discGroups = new List<DiscGroup>();
        int cursor = 1;
        foreach (var g in Store.Groups)
        {
            if (g.Tracks.Count == 0) continue;
            int first = cursor;
            foreach (var t in g.Tracks)
            {
                jobs.Add(new EncodeJob
                {
                    Index = meta.Count,
                    Title = t.Title,
                    Source = t.FilePath!,
                });
                meta.Add((t.Title, t.Artist, t.Album));
                cursor += 1;
            }
            discGroups.Add(new DiscGroup
            {
                Name = g.Name,
                First = first,
                Last = cursor - 1,
            });
        }
        int total = jobs.Count;
        int capacity = Store.BlankSectors;
        int workers = Store.EncodeWorkers;
        var handle = new EncodeHandle();
        Store.BeginEncode(handle, total, workers);

        var queue = DispatcherQueue;
        void Enqueue(Action action) => queue.TryEnqueue(() => action());
        // The success hop is async (it ends in the burn
        // offer), so it gets its own enqueue.
        void EnqueueAsync(Func<Task> action) =>
            queue.TryEnqueue(async () => await action());
        string isoPath = "";

        // Encode + author + write run off the UI thread; every
        // store touch hops back through the DispatcherQueue,
        // the BurnService pattern.
        Task.Run(() =>
        {
            try
            {
                var frames = EncodeService.EncodeAll(jobs, workers, handle,
                    (done, totalCount, title) => Enqueue(
                        () => Store.ApplyEncodeProgress(
                            handle, done, totalCount, title)));
                if (handle.IsCancelled) throw EncodeException.Cancelled();
                Enqueue(() => Store.ApplyEncodeAuthoring(handle));

                // Author with the proven core: a fresh random
                // DiscID and one IV per track, as the web app
                // generates them.
                var discTracks = new List<DiscTrack>();
                for (int i = 0; i < total; i++)
                {
                    discTracks.Add(new DiscTrack
                    {
                        Frames = frames[i],
                        Title = meta[i].Title,
                        Artist = meta[i].Artist,
                        Album = meta[i].Album,
                    });
                }
                var discId = new byte[16];
                var ivs = new List<byte[]>();
                using (var rng = RandomNumberGenerator.Create())
                {
                    rng.GetBytes(discId);
                    for (int i = 0; i < total; i++)
                    {
                        var iv = new byte[8];
                        rng.GetBytes(iv);
                        ivs.Add(iv);
                    }
                }
                var result = DiscAuthor.BuildDisc(
                    discTracks, discGroups, discId, ivs, capacity);
                string downloads = Path.Combine(
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.UserProfile),
                    "Downloads");
                Directory.CreateDirectory(downloads);
                isoPath = Path.Combine(downloads, "atrac-disc.iso");
                File.WriteAllBytes(isoPath, result.Iso);
                string line =
                    $"Built {isoPath} — {result.Stats.TrackCount} tracks, " +
                    $"{Format.MbString(result.Iso.Length)} MB, " +
                    $"{result.Stats.IsoSectors} sectors.";
                EnqueueAsync(async () =>
                {
                    Store.ApplyEncodeSuccess(handle, line);
                    Store.ImportIso(isoPath, fromEncode: true);
                    if (Store.Imported is { } imp2)
                        await BurnService.OfferBurnAsync(
                            this, imp2,
                            (state, success) =>
                                Store.ApplyBurnState(state, success),
                            Store.Log);
                });
            }
            catch (EncodeException ex)
                when (ex.Kind == EncodeFailureKind.Cancelled)
            {
                Enqueue(() => Store.ApplyEncodeCancelled(handle));
            }
            catch (Exception ex)
            {
                Enqueue(() => Store.ApplyEncodeFailed(handle, ex.Message));
            }
        });
    }

    // ---- blank picker ----

    private void BlankCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (BlankCombo.SelectedItem is not BlankOption opt) return;
        Store.BlankSelection = opt.Sectors;
        var vis = opt.Sectors == -1 ? Visibility.Visible : Visibility.Collapsed;
        CustomBlankBox.Visibility = vis;
        CustomBlankLabel.Visibility = vis;
    }

    // ---- group / track row buttons ----
    // (Each handler's DataContext is the row's model — the
    // classic-binding counterpart of the Swift row's bindings.)

    private void RemoveGroup_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is GroupItem g)
            Store.RemoveGroup(g);
    }

    private (GroupItem?, TrackItem?) RowOf(object sender)
    {
        var track = ((FrameworkElement)sender).DataContext as TrackItem;
        return (track == null ? null : Store.GroupOf(track), track);
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e)
    {
        var (g, t) = RowOf(sender);
        if (g != null && t != null) Store.MoveTrackUp(g, t);
    }

    private void MoveDown_Click(object sender, RoutedEventArgs e)
    {
        var (g, t) = RowOf(sender);
        if (g != null && t != null) Store.MoveTrackDown(g, t);
    }

    private void RemoveTrack_Click(object sender, RoutedEventArgs e)
    {
        var (g, t) = RowOf(sender);
        if (g != null && t != null) Store.RemoveTrack(g, t);
    }

    private void MoveToGroup_Click(object sender, RoutedEventArgs e)
    {
        var (g, t) = RowOf(sender);
        if (g == null || t == null) return;
        var others = Store.Groups.Where(o => o != g).ToList();
        if (others.Count == 0) return;
        var flyout = new MenuFlyout();
        foreach (var dest in others)
        {
            var item = new MenuFlyoutItem { Text = dest.Name };
            var target = dest;
            item.Click += (_, _) => Store.MoveTrackToGroup(t, g, target);
            flyout.Items.Add(item);
        }
        flyout.ShowAt((FrameworkElement)sender);
    }

    // ---- disc stage ----

    // CanvasControl, not CanvasAnimatedControl: Win2D documents the
    // animated control as unsupported for WinUI 3, and its swap chain
    // shows transparent pixels as opaque black — the stage rendered
    // solid black on first launch despite ClearColor="Transparent"
    // (Lola's catch, 2026-11-06). CanvasControl composites alpha
    // properly; the frame loop is CompositionTarget.Rendering +
    // Invalidate, with the painter fed plain elapsed time.
    private long _lastRenderTick;

    private void OnDiscRendering(object sender, object e)
    {
        long now = System.Diagnostics.Stopwatch.GetTimestamp();
        if (_lastRenderTick == 0) { _lastRenderTick = now; return; }
        double seconds = (now - _lastRenderTick) / (double)System.Diagnostics.Stopwatch.Frequency;
        _lastRenderTick = now;
        if (seconds > 0.1) seconds = 0.1;   // tab-switch / drag spike cap
        _painter.Update(TimeSpan.FromSeconds(seconds));
        DiscCanvas.Invalidate();
    }

    private void DiscCanvas_Draw(CanvasControl sender, CanvasDrawEventArgs args) =>
        _painter.Draw(args.DrawingSession, sender.Size);
}
