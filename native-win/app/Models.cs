// Models.cs — the app's list models, a port of Models.swift.
//
// Deliberately NOT the core's DiscTrack/DiscGroup (those are
// the authoring pipeline's input structs, built from encoded
// frames in Step 3). These are the UI's working copies: a
// track knows its source file path and its estimated sample
// count (from the audio file's duration, exactly like the web
// app's tracks), and an imported track knows it is read-only.
//
// Hand-rolled INotifyPropertyChanged instead of an MVVM
// package: the surface needed is tiny and one less NuGet
// restore risk rides along (see STEP2-NOTES.md).

using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace DiscWright;

/// <summary>Minimal INotifyPropertyChanged base.</summary>
public abstract class ObservableBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool SetProperty<T>(ref T field, T value,
                                  [CallerMemberName] string? name = null)
    {
        if (Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}

public sealed class TrackItem : ObservableBase
{
    public Guid Id { get; } = Guid.NewGuid();

    private string _name = "";
    private string _title = "";
    private string _artist = "";
    private string _album = "";
    private string? _filePath;
    private int _samples;
    private string? _error;
    private bool _imported;
    private int _size;

    /// <summary>Display/file name (the web app's track.name).</summary>
    public string Name { get => _name; set => SetProperty(ref _name, value); }
    public string Title { get => _title; set => SetProperty(ref _title, value); }
    public string Artist { get => _artist; set => SetProperty(ref _artist, value); }
    public string Album { get => _album; set => SetProperty(ref _album, value); }

    /// <summary>Source audio file; null for imported tracks.</summary>
    public string? FilePath { get => _filePath; set => SetProperty(ref _filePath, value); }

    /// <summary>Estimated samples at 44.1 kHz (duration * 44100),
    /// the web app's capacity basis. 0 = unknown / unreadable.</summary>
    public int Samples
    {
        get => _samples;
        set { if (SetProperty(ref _samples, value)) OnPropertyChanged(nameof(DurationText)); }
    }

    /// <summary>Non-null when the file could not be read/decoded
    /// (the web app shows "⚠ error" in the duration cell).</summary>
    public string? Error
    {
        get => _error;
        set
        {
            if (SetProperty(ref _error, value))
            {
                OnPropertyChanged(nameof(HasError));
                OnPropertyChanged(nameof(ErrorText));
            }
        }
    }

    public bool HasError => Error != null;

    /// <summary>"⚠ could not decode this file" — the row's
    /// error cell (red), shown instead of the duration.</summary>
    public string ErrorText => Error == null ? "" : "⚠ " + Error;

    /// <summary>Imported tracks are read-only: no edits,
    /// no row buttons.</summary>
    public bool Imported
    {
        get => _imported;
        set { if (SetProperty(ref _imported, value)) OnPropertyChanged(nameof(Editable)); }
    }

    /// <summary>The .ATP size on the disc, for imported tracks.</summary>
    public int Size { get => _size; set => SetProperty(ref _size, value); }

    public bool Editable => !Imported;

    /// <summary>The duration cell (the formatted duration;
    /// the error cell is ErrorText, shown instead when the
    /// file failed to read).</summary>
    public string DurationText => Format.FmtDuration(Samples);
}

public sealed class GroupItem : ObservableBase
{
    public Guid Id { get; } = Guid.NewGuid();

    private string _name = "";
    private bool _imported;
    private bool _canRemove;

    public GroupItem(string name, bool imported = false)
    {
        _name = name;
        _imported = imported;
    }

    public string Name { get => _name; set => SetProperty(ref _name, value); }
    public bool Imported
    {
        get => _imported;
        set { if (SetProperty(ref _imported, value)) OnPropertyChanged(nameof(Editable)); }
    }

    /// <summary>The group name field is disabled on imported
    /// discs (read-only), as on the Mac.</summary>
    public bool Editable => !Imported;

    /// <summary>Maintained by the store: the Remove-group
    /// button shows only when there is more than one group and
    /// the list is not an imported disc.</summary>
    public bool CanRemove { get => _canRemove; set => SetProperty(ref _canRemove, value); }

    public ObservableCollection<TrackItem> Tracks { get; } = new();
}

public static class Format
{
    /// <summary>JS Math.round / Swift Double.rounded() round
    /// halves AWAY FROM ZERO; C#'s Math.Round defaults to
    /// banker's rounding, so every mirrored rounding passes
    /// this explicitly.</summary>
    public static double RoundHalfAway(double v) =>
        Math.Round(v, MidpointRounding.AwayFromZero);

    /// <summary>fmtDuration(samples) from Models.swift: "…"
    /// for 0, otherwise m:ss of round(samples / 44100).</summary>
    public static string FmtDuration(int samples)
    {
        if (samples == 0) return "…";
        long s = (long)RoundHalfAway(samples / 44100.0);
        return $"{s / 60}:{s % 60:00}";
    }

    /// <summary>MB the way the web app prints it:
    /// (bytes / 1e6) rounded, as an integer string.</summary>
    public static string MbString(long bytes) =>
        ((long)RoundHalfAway(bytes / 1e6)).ToString();
}
