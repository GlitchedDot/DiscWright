// Store.cs — the app's state and every list operation, a port
// of DiscStore.swift. Step 2 brought the list half; Step 3
// (v26) adds the encode half: the workers setting, the encode
// state the stage reads (IsEncoding / EncodeProgress), and the
// encode lifecycle callbacks MainWindow reports through —
// mirroring the Swift store's startEncodeAndBuild state flow,
// with the orchestration itself in MainWindow + EncodeService.
// Mirrored semantics:
//  - groups are named, removable (their tracks move to the
//    previous group, or the next one for the first group),
//  - tracks move up/down, between groups, and by drag (the
//    ListView reorders the bound collection itself),
//  - bare files land in the LAST group; a picked folder becomes
//    a group named after it (created or reused by name), walked
//    up to 2 folders deep, audio only, in path order,
//  - capacity = IsoSectorCount(estimatedSizes) + the session
//    overhead, against the chosen blank,
//  - importing an ISO replaces the list with that disc's own
//    groups/tracks, read-only, and Burn Disc burns that file.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using DiscWright.Core;
using Windows.Storage;

namespace DiscWright;

/// <summary>An imported disc: what the capacity line and the
/// burner need. (ImportedDisc in Store.swift.)</summary>
public sealed class ImportedDisc
{
    public string Name = "";
    public long Size;
    public string FilePath = "";
    /// <summary>Set when this "imported" disc is one the app
    /// itself just encoded (Burn Disc's offer then uses the
    /// "encoded and ready" wording, not "you imported").</summary>
    public bool FromEncode;
}

/// <summary>The burn's lifecycle, reported to the store: the
/// stage status line and the spinning laser key off it.
/// (BurnState in BurnService.swift.)</summary>
public enum BurnState
{
    Started,
    Finished,
}

public sealed class DiscStore : ObservableBase
{
    public const string IdleStatus = "Please select a type of disc.";

    /// <summary>The blank picker's fixed entries, in the web
    /// app's order (DiscStore.blankOptions).</summary>
    public static readonly int[] BlankOptions =
        { 360000, 333000, 108000, 94500, 405000, 445500 };

    private static readonly HashSet<string> AudioExts =
        new() { "mp3", "m4a", "wav", "flac", "ogg", "aif", "aiff" };

    public ObservableCollection<GroupItem> Groups { get; } = new();
    public ObservableCollection<string> LogLines { get; } = new();

    private ImportedDisc? _imported;
    private int _blankSelection = 360000;
    private string _customBlankText = "360000";
    private bool _isBurning;
    private string _stageStatus = IdleStatus;
    private bool _isEncoding;
    private double? _encodeProgress;
    private int _encodeWorkers = LoadWorkers();
    private EncodeHandle? _encodeHandle;

    /// <summary>Raised after any mutation that changes derived
    /// display state (capacity, button enables, group flags).
    /// MainWindow refreshes the parts XAML binding cannot reach
    /// (the meter fill width) from this.</summary>
    public event EventHandler? StateChanged;

    public DiscStore()
    {
        Groups.CollectionChanged += OnGroupsChanged;
        // OnGroupsChanged (subscribed above) watches each
        // group as it is added.
        Groups.Add(new GroupItem("Group 1"));
        Log("Ready.");
        Log("Add tracks, then Burn Disc — a new disc encodes, authors, and offers its burn in one go. Import ISO + burn works too.");
        Refresh();
    }

    // ---- state properties ----

    public ImportedDisc? Imported
    {
        get => _imported;
        private set { if (SetProperty(ref _imported, value)) Refresh(); }
    }

    /// <summary>Picker selection: a BLANKS sector count,
    /// or -1 for Custom (DiscStore.blankSelection).</summary>
    public int BlankSelection
    {
        get => _blankSelection;
        set { if (SetProperty(ref _blankSelection, value)) Refresh(); }
    }

    public string CustomBlankText
    {
        get => _customBlankText;
        set { if (SetProperty(ref _customBlankText, value)) Refresh(); }
    }

    /// <summary>True while a burn runs (the disc stage spins
    /// the laser and Burn Disc stays disabled meanwhile).</summary>
    public bool IsBurning
    {
        get => _isBurning;
        private set { if (SetProperty(ref _isBurning, value)) Refresh(); }
    }

    /// <summary>The disc stage's status line — the web app's
    /// #stageStatus. The idle text is the web's exact line.</summary>
    public string StageStatus
    {
        get => _stageStatus;
        private set => SetProperty(ref _stageStatus, value);
    }

    /// <summary>True while a Burn Disc encode runs (drives
    /// the Cancel button's enable and locks Burn Disc).</summary>
    public bool IsEncoding
    {
        get => _isEncoding;
        private set { if (SetProperty(ref _isEncoding, value)) Refresh(); }
    }

    /// <summary>The encode's real progress for the stage's
    /// laser: null when no encode is in flight, 0.85 ×
    /// done/total while tracks encode, 1.0 while the disc is
    /// authored — the Mac's numbers, read by DiscPainter.</summary>
    public double? EncodeProgress
    {
        get => _encodeProgress;
        private set => SetProperty(ref _encodeProgress, value);
    }

    /// <summary>The machine's core count — the workers
    /// selector's ceiling (the Mac's activeProcessorCount).</summary>
    public static int MaxWorkers => Environment.ProcessorCount;

    /// <summary>The user's encode-workers choice: how many
    /// tracks encode in parallel. Clamped to 1..MaxWorkers and
    /// persisted to a plain settings file (see LoadWorkers —
    /// an unpackaged app has no package identity, so
    /// ApplicationData.Current is NOT available to it).</summary>
    public int EncodeWorkers
    {
        get => _encodeWorkers;
        set
        {
            int clamped = Math.Clamp(value, 1, MaxWorkers);
            if (SetProperty(ref _encodeWorkers, clamped)) SaveWorkers();
        }
    }

    // ---- settings file (%LOCALAPPDATA%\DiscWright\settings.txt) ----

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiscWright", "settings.txt");

    /// <summary>The saved workers count, or the standing
    /// default — every core but one, capped at 8 (the Mac's
    /// defaultWorkers). A missing or broken file must never
    /// block launch, hence the quiet catch.</summary>
    private static int LoadWorkers()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                foreach (string line in File.ReadAllLines(SettingsPath))
                {
                    var parts = line.Split('=', 2);
                    if (parts.Length == 2 && parts[0].Trim() == "encodeWorkers"
                        && int.TryParse(parts[1].Trim(), out int v))
                        return Math.Clamp(v, 1, MaxWorkers);
                }
            }
        }
        catch { /* fall through to the default */ }
        return Math.Clamp(Math.Max(Environment.ProcessorCount - 1, 1), 1, 8);
    }

    private void SaveWorkers()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, $"encodeWorkers={_encodeWorkers}\n");
        }
        catch { /* persistence is a courtesy, never a crash */ }
    }

    // ---- log ----

    public void Log(string line)
    {
        LogLines.Add(line);
        while (LogLines.Count > 500) LogLines.RemoveAt(0);
    }

    // ---- derived state ----

    public List<TrackItem> AllTracks => Groups.SelectMany(g => g.Tracks).ToList();

    public int BlankSectors =>
        BlankSelection == -1
            ? (int.TryParse(CustomBlankText, out int v) ? v : 360000)
            : BlankSelection;

    /// <summary>The web app's estimatedSizes(): per-file byte
    /// sizes the ISO planner would see. Frames per track come
    /// from the duration estimate: floor(samples / 2048) + 1,
    /// 376 bytes each, + 1120.</summary>
    public Dictionary<string, int> EstimatedSizes()
    {
        var sizes = new Dictionary<string, int>();
        var tracks = AllTracks;
        for (int i = 0; i < tracks.Count; i++)
        {
            int frames = tracks[i].Samples != 0 ? tracks[i].Samples / 2048 + 1 : 0;
            sizes["/HIFI/" + DiscAuthor.TrackFilename(i + 1)] = frames * 376 + 1120;
        }
        sizes["/TRACK.NDB"] = Ndb.WriteNdb(tracks.Select(t => t.Title).ToList()).Length;
        sizes["/ALBUM.NDB"] = Ndb.WriteNdb(tracks.Select(t => t.Album).ToList()).Length;
        sizes["/ARTIST.NDB"] = Ndb.WriteNdb(tracks.Select(t => t.Artist).ToList()).Length;
        sizes["/GROUP.NDB"] = Ndb.WriteNdb(
            Groups.Where(g => g.Tracks.Count > 0).Select(g => g.Name).ToList()).Length;
        sizes["/PLLIST.NDB"] = 256;
        sizes["/TOC00000.STI"] = 0x900 + 16 * tracks.Count;
        sizes["/TOC00001.STI"] = 2176;
        sizes["/0001000E.STK"] = 172;
        return sizes;
    }

    public int UsedSectors =>
        Iso.IsoSectorCount(EstimatedSizes()) + Capacity.SessionOverheadSectors;

    public bool CapacityOver => Imported == null && UsedSectors > BlankSectors;

    public double CapacityFraction
    {
        get
        {
            if (Imported is { } imp)
            {
                double capBytes = (double)BlankSectors * Capacity.Sector;
                return capBytes > 0 ? Math.Min(1, imp.Size / capBytes) : 1;
            }
            return BlankSectors > 0
                ? Math.Min(1, (double)UsedSectors / BlankSectors)
                : 1;
        }
    }

    public string CapacityText
    {
        get
        {
            var tracks = AllTracks;
            int n = tracks.Count;
            if (Imported is { } imp)
            {
                return $"Imported disc “{imp.Name}” — {n} track{(n == 1 ? "" : "s")} · " +
                       $"{Format.MbString(imp.Size)} MB (the ISO itself)";
            }
            return $"{n} track{(n == 1 ? "" : "s")} · " +
                   $"{Format.MbString((long)UsedSectors * Capacity.Sector)} MB of " +
                   $"{Format.MbString((long)BlankSectors * Capacity.Sector)} MB" +
                   (CapacityOver ? " — over capacity!" : "");
        }
    }

    public string LibInfoText
    {
        get
        {
            if (AllTracks.Count == 0) return "";
            int g = Groups.Count(gr => gr.Tracks.Count > 0);
            return $"{g} group{(g == 1 ? "" : "s")}";
        }
    }

    /// <summary>The final Burn Disc rule: with an imported
    /// (or just-encoded) ISO it burns straight away; with a
    /// new list it runs the encode first, then offers the
    /// burn. Never while encoding or burning.</summary>
    public bool BurnEnabled =>
        !IsEncoding && !IsBurning &&
        (Imported != null || AllTracks.Count > 0);

    public bool HasImported => Imported != null;

    public bool IntakeEnabled => Imported == null;

    // ---- change plumbing ----

    private void OnGroupsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null)
            foreach (GroupItem g in e.NewItems) WatchGroup(g);
        Refresh();
    }

    private void WatchGroup(GroupItem g)
    {
        g.Tracks.CollectionChanged += (_, _) => Refresh();
        g.PropertyChanged += (_, args) =>
        {
            // A group rename changes GROUP.NDB's size.
            if (args.PropertyName == nameof(GroupItem.Name)) Refresh();
        };
    }

    /// <summary>Recompute every derived display value and the
    /// groups' CanRemove flags, then tell the window.</summary>
    public void Refresh()
    {
        foreach (var g in Groups)
            g.CanRemove = Groups.Count > 1 && Imported == null && !g.Imported;
        OnPropertyChanged(nameof(CapacityText));
        OnPropertyChanged(nameof(CapacityFraction));
        OnPropertyChanged(nameof(CapacityOver));
        OnPropertyChanged(nameof(BurnEnabled));
        OnPropertyChanged(nameof(HasImported));
        OnPropertyChanged(nameof(IntakeEnabled));
        OnPropertyChanged(nameof(LibInfoText));
        OnPropertyChanged(nameof(BlankSectors));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // ---- group operations ----

    public void AddGroup()
    {
        if (Imported != null) return;
        Groups.Add(new GroupItem($"Group {Groups.Count + 1}"));
    }

    /// <summary>Remove a group; its tracks move to the previous
    /// group (the next one when removing the first), as in the
    /// web app.</summary>
    public void RemoveGroup(GroupItem group)
    {
        if (Groups.Count <= 1) return;
        int gi = Groups.IndexOf(group);
        if (gi < 0) return;
        int dest = gi == 0 ? 1 : gi - 1;
        foreach (var t in group.Tracks.ToList()) Groups[dest].Tracks.Add(t);
        Groups.RemoveAt(gi);
    }

    // ---- track operations ----

    public void RemoveTrack(GroupItem group, TrackItem track) =>
        group.Tracks.Remove(track);

    public void MoveTrackUp(GroupItem group, TrackItem track) =>
        MoveTrack(group, track, -1);

    public void MoveTrackDown(GroupItem group, TrackItem track) =>
        MoveTrack(group, track, +1);

    private void MoveTrack(GroupItem group, TrackItem track, int delta)
    {
        int ti = group.Tracks.IndexOf(track);
        int to = ti + delta;
        if (ti < 0 || to < 0 || to >= group.Tracks.Count) return;
        group.Tracks.Move(ti, to);
    }

    /// <summary>Move a track to the END of another group (the
    /// web app's move-to-group select does exactly this).</summary>
    public void MoveTrackToGroup(TrackItem track, GroupItem from, GroupItem to)
    {
        if (from == to) return;
        if (from.Tracks.Remove(track)) to.Tracks.Add(track);
    }

    public GroupItem? GroupOf(TrackItem track) =>
        Groups.FirstOrDefault(g => g.Tracks.Contains(track));

    // ---- adding files ----

    public async Task AddFilesAsync(IReadOnlyList<string> paths)
    {
        var target = Groups.LastOrDefault();
        if (target == null) return;
        foreach (var p in paths) await AddFileAsync(p, target);
    }

    /// <summary>One file: tags first, then the duration
    /// estimate, then it joins the list (the web app's order,
    /// minus its placeholder row: results here appear once
    /// known).</summary>
    public async Task AddFileAsync(string path, GroupItem target)
    {
        var item = new TrackItem
        {
            Name = Path.GetFileName(path),
            Title = "",
            Artist = "",
            Album = "",
            FilePath = path,
            Samples = 0,
            Error = null,
            Imported = false,
            Size = 0,
        };
        try
        {
            var tags = TagReader.TagsForFile(path);
            item.Title = tags.Title;
            item.Artist = tags.Artist;
            item.Album = tags.Album;
            // Duration via the file's shell music properties
            // (WinRT) — the Windows counterpart of the Mac's
            // AVURLAsset.load(.duration). samples = round(sec *
            // 44100), the web app's capacity basis.
            var file = await StorageFile.GetFileFromPathAsync(path);
            var props = await file.Properties.GetMusicPropertiesAsync();
            double secs = props.Duration.TotalSeconds;
            if (double.IsFinite(secs) && secs > 0)
                item.Samples = (int)Format.RoundHalfAway(secs * 44100);
            else
                item.Error = "could not decode this file";
        }
        catch
        {
            item.Error = "could not decode this file";
        }
        target.Tracks.Add(item);
    }

    /// <summary>A picked folder: collect audio (≤ 2 folders
    /// deep, path order), then add it all to a group named
    /// after the folder — created on first sight, reused if
    /// the name already exists.</summary>
    public async Task AddFolderAsync(string root)
    {
        var (files, skipped) = CollectFolder(root);
        if (files.Count > 0 || skipped > 0)
        {
            Log($"Folder scan: added {files.Count} audio file{(files.Count == 1 ? "" : "s")}" +
                (skipped > 0 ? $", skipped {skipped} (not audio, or deeper than 2 folders)" : "") +
                ".");
        }
        if (files.Count == 0) return;
        string name = new DirectoryInfo(root).Name;
        var group = Groups.FirstOrDefault(g => g.Name == name);
        if (group == null)
        {
            group = new GroupItem(name);
            Groups.Add(group);
        }
        foreach (var f in files) await AddFileAsync(f, group);
        int count = group.Tracks.Count;
        Log($"Folder “{name}” became a group ({count} track{(count == 1 ? "" : "s")}).");
    }

    /// <summary>Enumerate a folder the way the web app's intake
    /// does: regular files only, hidden files skipped; a file
    /// counts as "deep" by the folders between the picked root
    /// and it (the root's own files are depth 0; depth ≤ 2 is
    /// collected).</summary>
    private static (List<string> files, int skipped) CollectFolder(string root)
    {
        var files = new List<string>();
        int skipped = 0;
        foreach (var path in Directory.EnumerateFiles(
                     root, "*", SearchOption.AllDirectories))
        {
            var info = new FileInfo(path);
            // The web/Swift intake skips hidden files entirely
            // (they are not even counted as skipped).
            if ((info.Attributes & System.IO.FileAttributes.Hidden) != 0) continue;
            string rel = Path.GetRelativePath(root, path);
            int depth = rel.Split(Path.DirectorySeparatorChar,
                                  Path.AltDirectorySeparatorChar).Length - 1;
            string ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
            if (depth <= 2 && AudioExts.Contains(ext))
                files.Add(path);
            else
                skipped++;
        }
        // Path order — Explorer's logical sort, the closest
        // Windows counterpart of localizedStandardCompare.
        files.Sort(LogicalPathComparer.Instance);
        return (files, skipped);
    }

    // ---- import ISO ----

    public void ImportIso(string path, bool fromEncode = false)
    {
        try
        {
            byte[] data = File.ReadAllBytes(path);
            var disc = IsoRead.ParseAtracDisc(data);
            Groups.Clear();
            foreach (var g in disc.Groups)
            {
                var group = new GroupItem(g.Name, imported: true);
                foreach (var t in g.Tracks)
                {
                    group.Tracks.Add(new TrackItem
                    {
                        Name = t.Title.Length == 0 ? "Track" : t.Title,
                        Title = t.Title,
                        Artist = t.Artist,
                        Album = t.Album,
                        FilePath = null,
                        Samples = t.Seconds * 44100,
                        Error = null,
                        Imported = true,
                        Size = t.Size,
                    });
                }
                Groups.Add(group);
            }
            Imported = new ImportedDisc
            {
                Name = Path.GetFileName(path),
                Size = data.Length,
                FilePath = path,
                FromEncode = fromEncode,
            };
            Log($"Imported “{Path.GetFileName(path)}”: {disc.TrackCount} " +
                $"track{(disc.TrackCount == 1 ? "" : "s")} in {disc.Groups.Count} " +
                $"group{(disc.Groups.Count == 1 ? "" : "s")}, {Format.MbString(data.Length)} MB.");
            Log("This disc is already authored — its tracks are read-only. " +
                "Clear the imported disc to start a new one.");
            Refresh();
        }
        catch (Exception ex)
        {
            Log($"Import failed: {ex.Message}");
        }
    }

    public void ClearImport()
    {
        Imported = null;
        Groups.Clear();
        Groups.Add(new GroupItem("Group 1"));
        StageStatus = IdleStatus;
        Log("Imported disc cleared.");
        Refresh();
    }

    // ---- burn (imported ISO; driven by MainWindow, whose
    // window the confirmation dialog needs) ----

    /// <summary>The store half of the Swift burnDiscClicked
    /// closure: BurnService reports .started/.finished and the
    /// stage status follows, exactly as on the Mac.</summary>
    public void ApplyBurnState(BurnState state, bool success = false)
    {
        switch (state)
        {
            case BurnState.Started:
                IsBurning = true;
                StageStatus = "Writing — burning the disc…";
                break;
            case BurnState.Finished:
                IsBurning = false;
                StageStatus = success
                    ? "Your disc is ready. 💿"
                    : "Something went wrong — see the log below.";
                break;
        }
        Refresh();
    }

    // ---- encode (Step 3; driven by MainWindow, whose Burn
    // Disc click snapshots the jobs and runs EncodeService +
    // DiscAuthor.BuildDisc off the UI thread, reporting back
    // through these methods on the UI thread — the counterpart
    // of the Swift store's startEncodeAndBuild state flow) ----

    /// <summary>A pre-flight refusal (the Mac's build guards):
    /// the log names the problem and the stage shows the
    /// standard error line. Nothing was started.</summary>
    public void FailBeforeBuild(string logLine)
    {
        Log(logLine);
        StageStatus = "Something went wrong — see the log below.";
    }

    public void BeginEncode(EncodeHandle handle, int total, int workers)
    {
        _encodeHandle = handle;
        IsEncoding = true;
        IsBurning = true; // the stage spins + draws the laser throughout
        EncodeProgress = 0;
        StageStatus = $"Writing — 0 of {total} tracks encoded";
        Log($"Encoding {total} track{(total == 1 ? "" : "s")} " +
            $"with {workers} worker{(workers == 1 ? "" : "s")}…");
        Refresh();
    }

    public void ApplyEncodeProgress(EncodeHandle handle, int done,
                                    int total, string title)
    {
        if (!ReferenceEquals(_encodeHandle, handle)) return;
        EncodeProgress = 0.85 * done / total;
        StageStatus = $"Writing — {done} of {total} tracks encoded";
        Log($"Encoded {done}/{total}: {title}");
    }

    public void ApplyEncodeAuthoring(EncodeHandle handle)
    {
        if (!ReferenceEquals(_encodeHandle, handle)) return;
        EncodeProgress = 1.0;
        StageStatus = "Writing — authoring the disc…";
    }

    /// <summary>The ISO is written. The built line carries the
    /// full path and size (the Mac's "Built …" log line), and
    /// the stage lands on the same ready text a finished burn
    /// uses — the window then auto-imports the ISO it just
    /// built (marked FromEncode) and offers its burn, the
    /// proven Import ISO path, with no Downloads detour by
    /// hand.</summary>
    public void ApplyEncodeSuccess(EncodeHandle handle, string builtLine)
    {
        if (!ReferenceEquals(_encodeHandle, handle)) return;
        Log(builtLine);
        EndEncode();
        StageStatus = "Your disc is ready. 💿";
        Refresh();
    }

    public void ApplyEncodeFailed(EncodeHandle handle, string message)
    {
        if (!ReferenceEquals(_encodeHandle, handle)) return;
        EndEncode();
        StageStatus = "Something went wrong — see the log below.";
        Log($"Build failed: {message}");
        Refresh();
    }

    public void ApplyEncodeCancelled(EncodeHandle handle)
    {
        if (!ReferenceEquals(_encodeHandle, handle)) return;
        EndEncode();
        StageStatus = IdleStatus;
        Log("Encoding cancelled — no disc was built.");
        Refresh();
    }

    private void EndEncode()
    {
        _encodeHandle = null;
        IsEncoding = false;
        IsBurning = false;
        EncodeProgress = null;
    }

    /// <summary>Cancel the in-flight encode (pending jobs drop
    /// out, running child processes are killed).</summary>
    public void CancelEncode() => _encodeHandle?.Cancel();
}

/// <summary>Explorer's logical path ordering (StrCmpLogicalW)
/// — digits compare by value, like Finder's sort and the Mac
/// intake's localizedStandardCompare.</summary>
public sealed class LogicalPathComparer : IComparer<string>
{
    public static readonly LogicalPathComparer Instance = new();

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int StrCmpLogicalW(string psz1, string psz2);

    public int Compare(string? x, string? y) =>
        StrCmpLogicalW(x ?? "", y ?? "");
}
